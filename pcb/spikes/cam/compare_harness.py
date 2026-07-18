#!/usr/bin/env python
"""Harness-backed comparison of the gerbonara coupon vs the BLESSED golden.

Uses the SB.1-3 verification harness (pcb/worker/tests/oracle) — NOT by-eye:
  * gerbonara round-trip parse of every gerbonara-emitted layer + drill file.
  * geometry_diff of the gerbonara coupon vs the blessed golden (spike-gerber-v1)
    on the layers whose shapes overlap (F/B copper, F/B mask, Edge_Cuts, drills),
    incl. drill-to-copper registration.
  * X2 recognition: re-parse and confirm %TF file attributes survive round-trip.
  * IPC-356 round-trip: re-parse the netlist, confirm nets.
  * kicad-cli DRC oracle note (dev-only; runs on the canonical board via the
    worker's KiCad emitter — the oracle checks board geometry, not the emitter).

Run: python compare_harness.py
"""
from __future__ import annotations

import sys
import warnings
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]                      # minerva-plugins
sys.path.insert(0, str(REPO / "pcb" / "worker"))
sys.path.insert(0, str(REPO / "pcb" / "worker" / "tests"))

from gerbonara import GerberFile, ExcellonFile          # noqa: E402
from gerbonara.ipc356 import Netlist                     # noqa: E402
from gerbonara.cam import FileSettings                   # noqa: E402
from gerbonara.utils import MM                           # noqa: E402

SETTINGS_DIFF = FileSettings(unit=MM, number_format=(3, 6), zeros="leading",
                             notation="absolute")
from oracle.geometry_diff import (                        # noqa: E402
    parse_output_set, diff_geometry, registration_violations, load_output_dir,
)

GOLDEN_DIR = REPO / "pcb" / "spikes" / "gerber" / "golden"
# Layers/drills where the gerbonara coupon and the golden describe the SAME shapes.
OVERLAP = {"board-F_Cu.gbr", "board-B_Cu.gbr", "board-F_Mask.gbr",
           "board-B_Mask.gbr", "board-Edge_Cuts.gbr",
           "board-PTH.drl", "board-NPTH.drl"}


def rule(t):
    print(f"\n{'='*70}\n{t}\n{'='*70}")


def main() -> None:
    import gerbonara_coupon
    files = gerbonara_coupon.build()

    rule("1. gerbonara ROUND-TRIP parse of the gerbonara coupon")
    gbrs = {n: t for n, t in files.items() if n.endswith(".gbr")}
    drls = {n: t for n, t in files.items() if n.endswith(".drl")}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        for n, t in gbrs.items():
            gf = GerberFile.from_string(t, filename=n)
            aps = list(gf.apertures())
            objs = list(gf.objects)
            print(f"  {n:22s} objects={len(objs):2d} apertures={len(aps)} empty={gf.is_empty}")
        for n, t in drls.items():
            ef = ExcellonFile.from_string(t, filename=n)
            hits = sum(ef.hit_count().values())
            slots = list(ef.slots())
            print(f"  {n:22s} hits={hits} slots={len(slots)} sizes={sorted(round(d,3) for d in ef.drill_sizes())}")

    rule("2. GEOMETRY DIFF: gerbonara coupon vs BLESSED golden (overlap layers)")
    # HARNESS GAP: geometry_diff.parse_drill_file assumes every Excellon object
    # is a Flash (reads o.x); it crashes on a routed SLOT (a Line, has x1/y1).
    # The golden has no slots, so strip the coupon's slot for the OVERLAP diff and
    # report the slot separately. (Finding: SB.2 geometry_diff needs slot support.)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        pth_noslot = ExcellonFile.from_string(files["board-PTH.drl"], filename="board-PTH.drl")
        pth_noslot.objects = [o for o in pth_noslot.objects if type(o).__name__ == "Flash"]
        files_diff = dict(files)
        files_diff["board-PTH.drl"] = pth_noslot.write_to_bytes(settings=SETTINGS_DIFF).decode()
    coupon_overlap = {n: t for n, t in files_diff.items() if n in OVERLAP}
    golden_files = {n: t for n, t in load_output_dir(GOLDEN_DIR).items() if n in OVERLAP}
    cur = parse_output_set(coupon_overlap)
    gold = parse_output_set(golden_files)
    diff = diff_geometry(cur, gold)
    if diff.is_empty:
        print("  GEOMETRY IDENTICAL to blessed golden on all overlap layers.")
    else:
        # Categorize: silk/pour/arc extras are EXPECTED (coupon adds features);
        # copper/mask/drill/registration deltas would be real divergence.
        by_layer = {}
        for d in diff.deltas:
            by_layer.setdefault(d.layer, []).append(d)
        for layer in sorted(by_layer):
            print(f"  [{layer}] {len(by_layer[layer])} delta(s):")
            for d in by_layer[layer][:8]:
                print(f"      {d.change:8s} {d.category:12s} {d.detail}")

    rule("3. DRILL-TO-COPPER REGISTRATION (coupon)")
    viol = registration_violations(parse_output_set({n: t for n, t in files_diff.items()
                                                     if n.endswith((".gbr", ".drl"))}))
    print(f"  plated-drill-without-copper violations: {len(viol)}")
    for v in viol:
        print(f"      {v}")

    rule("4. X2 FILE-ATTRIBUTE recognition (round-trip)")
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        gf = GerberFile.from_string(files["board-F_Cu.gbr"], filename="board-F_Cu.gbr")
    print(f"  F_Cu file_attrs after round-trip: {dict(gf.file_attrs)}")
    obj_attrs = [o.attrs for o in gf.objects if getattr(o, 'attrs', None)]
    print(f"  object (.TO net) attrs recovered: {obj_attrs or 'NONE (gerbonara writer drops TO/TA)'}")

    rule("5. IPC-356 netlist round-trip")
    nl = Netlist.from_string(files["board.ipc356"], filename="board.ipc356")
    print(f"  nets: {sorted(nl.net_names())}")
    print(f"  test records: {len(list(nl.objects()) if callable(getattr(nl,'objects',None)) else nl.test_records)}")

    rule("6. kicad-cli DRC oracle availability (dev-only)")
    try:
        from oracle.kicad_drc import kicad_cli_available
        print(f"  kicad-cli on PATH: {kicad_cli_available()} "
              f"(oracle checks canonical-board geometry via worker KiCad emitter, "
              f"NOT the CAM emitter — same for both writer paths)")
    except Exception as e:  # noqa: BLE001
        print(f"  kicad_drc import note: {e}")


if __name__ == "__main__":
    main()
