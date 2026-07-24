#!/usr/bin/env python
"""Gerber-writer validation spike: generate a tiny 2-layer test board.

Board geometry mirrors board.yaml (canonical board-source contract terms).
Emits RS-274X/X2 layers via the `gerber_writer` library (F.Cu, B.Cu, F.Mask,
B.Mask, F.SilkS, Edge.Cuts) plus hand-written Excellon drill files (PTH and
NPTH) since gerber_writer has no Excellon support at all (confirmed by
reading its source: no `excellon` module, no drill-related class).

Run: python generate.py [output_dir]   (defaults to ./golden)
"""
import datetime
import sys
from pathlib import Path

from gerber_writer import (
    DataLayer,
    Path as GPath,
    Circle,
    Rectangle,
    set_generation_software,
)

OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "golden"
OUT.mkdir(parents=True, exist_ok=True)

set_generation_software("Minerva", "gerber-writer-spike/generate.py", "1.0")

# --- Board geometry constants (mirrors board.yaml) -------------------------

BOARD_W, BOARD_H = 40.0, 30.0

R1 = (10.0, 10.0)   # pins at R1 +/- 0.95 on X
C1 = (10.0, 20.0)
U1 = (30.0, 15.0)   # single TH pad
VIA = (20.0, 10.0)
MOUNTING_HOLE = (5.0, 5.0)

SMD_PAD_X, SMD_PAD_Y = 1.0, 1.45   # real 0805 land (KiCad R/C_0805_2012Metric)
TRACE_W = 0.25
TH_DRILL = 0.8
TH_ANNULUS = 1.6
VIA_DRILL = 0.4
VIA_DIAMETER = 0.8
MASK_CLEARANCE = 0.05  # per-side growth for solder mask openings. RATIFIED to
# match PRODUCTION (owner decision, K4 correctness-oracle bug 019f91f9e89c): the
# compile->IR fab path resolves the board's solder_mask_clearance_mm from
# compile_board._DEFAULTS (0.05mm), so this INDEPENDENT golden must be cut at the
# same clearance for the correctness oracle to certify user-facing CAM. Was 0.1mm
# (legacy DEFAULT_MASK_CLEARANCE_MM in gerber.py, which now only applies to the raw
# test path). The NPTH mount mask below is a drill-size opening and is unaffected.
MOUNT_HOLE_DIA = 3.2

r1_pin1 = (R1[0] - 0.95, R1[1])
r1_pin2 = (R1[0] + 0.95, R1[1])
c1_pin1 = (C1[0] - 0.95, C1[1])
c1_pin2 = (C1[0] + 0.95, C1[1])

# --- Pad masters -------------------------------------------------------------

# Mask openings grow the copper land by MASK_CLEARANCE per side. round() keeps the
# emitted diameter clean (e.g. 1.6 + 2*0.05 = 1.7, not 1.7000000000000002 from
# binary float) — the correctness oracle is geometry-tolerant, but a clean golden
# is easier to bless and diff.
smd_pad = Rectangle(SMD_PAD_X, SMD_PAD_Y, "SMDPad,CuDef")
smd_mask_pad = Rectangle(round(SMD_PAD_X + 2 * MASK_CLEARANCE, 4),
                         round(SMD_PAD_Y + 2 * MASK_CLEARANCE, 4), "")
th_pad_cu = Circle(TH_ANNULUS, "ComponentPad")
th_mask_pad = Circle(round(TH_ANNULUS + 2 * MASK_CLEARANCE, 4), "")
via_pad_cu = Circle(VIA_DIAMETER, "ViaPad")
# NPTH mounting-hole mask: a DRILL-SIZE opening (no clearance growth) on BOTH
# sides. Ground truth is pcbnew 9.0.9 — a KiCad np_thru_hole pad IS on F.Mask/
# B.Mask with a size==drill opening; the emitter matches (E3, docket
# 019f901a9966). Kept independent of the emitter: this is gerber_writer.
mount_mask_pad = Circle(MOUNT_HOLE_DIA, "")

# =============================================================================
# F.Cu
# =============================================================================
f_cu = DataLayer("Copper,L1,Top,Signal", negative=False)
f_cu.add_pad(smd_pad, r1_pin1)
f_cu.add_pad(smd_pad, r1_pin2)
f_cu.add_pad(smd_pad, c1_pin1)
f_cu.add_pad(smd_pad, c1_pin2)
f_cu.add_pad(th_pad_cu, U1)          # TH pad has copper on every copper layer
f_cu.add_pad(via_pad_cu, VIA)
# VCC: R1.2 -> via
f_cu.add_trace_line(r1_pin2, VIA, TRACE_W, "Conductor")
# GND: R1.1 -> C1.1
f_cu.add_trace_line(r1_pin1, c1_pin1, TRACE_W, "Conductor")

with open(OUT / "board-F_Cu.gbr", "w") as fh:
    f_cu.dump_gerber(fh)

# =============================================================================
# B.Cu
# =============================================================================
b_cu = DataLayer("Copper,L2,Bot,Signal", negative=False)
b_cu.add_pad(th_pad_cu, U1)
b_cu.add_pad(via_pad_cu, VIA)
# VCC: via -> U1 TH pad, single trace on B.Cu
b_cu.add_trace_line(VIA, U1, TRACE_W, "Conductor")

with open(OUT / "board-B_Cu.gbr", "w") as fh:
    b_cu.dump_gerber(fh)

# =============================================================================
# F.Mask (openings; vias left tented -> not present in mask layer)
# =============================================================================
f_mask = DataLayer("Soldermask,Top", negative=False)
f_mask.add_pad(smd_mask_pad, r1_pin1)
f_mask.add_pad(smd_mask_pad, r1_pin2)
f_mask.add_pad(smd_mask_pad, c1_pin1)
f_mask.add_pad(smd_mask_pad, c1_pin2)
f_mask.add_pad(th_mask_pad, U1)
f_mask.add_pad(mount_mask_pad, MOUNTING_HOLE)   # NPTH: drill-size opening

with open(OUT / "board-F_Mask.gbr", "w") as fh:
    f_mask.dump_gerber(fh)

# =============================================================================
# B.Mask (U1's TH pad copper + the NPTH mounting-hole drill-size opening)
# =============================================================================
b_mask = DataLayer("Soldermask,Bot", negative=False)
b_mask.add_pad(th_mask_pad, U1)
b_mask.add_pad(mount_mask_pad, MOUNTING_HOLE)   # NPTH: drill-size opening

with open(OUT / "board-B_Mask.gbr", "w") as fh:
    b_mask.dump_gerber(fh)

# =============================================================================
# F.SilkS -- component courtyard outlines + a pin-1 tick for U1
# =============================================================================
f_silks = DataLayer("Legend,Top", negative=False)


def _courtyard(center, half_w, half_h):
    p = GPath()
    cx, cy = center
    p.moveto((cx - half_w, cy - half_h))
    p.lineto((cx + half_w, cy - half_h))
    p.lineto((cx + half_w, cy + half_h))
    p.lineto((cx - half_w, cy + half_h))
    p.lineto((cx - half_w, cy - half_h))
    return p


f_silks.add_traces_path(_courtyard(R1, 1.6, 1.0), 0.15, "")
f_silks.add_traces_path(_courtyard(C1, 1.6, 1.0), 0.15, "")
# Pin-1 tick mark near U1 (short line offset from the pad, not overlapping copper)
tick = GPath()
tick.moveto((U1[0] - TH_ANNULUS / 2 - 0.6, U1[1]))
tick.lineto((U1[0] - TH_ANNULUS / 2 - 0.2, U1[1]))
f_silks.add_traces_path(tick, 0.15, "")

with open(OUT / "board-F_SilkS.gbr", "w") as fh:
    f_silks.dump_gerber(fh)

# =============================================================================
# Edge.Cuts -- board outline rectangle, 0,0 -> 40,30
# =============================================================================
edge_cuts = DataLayer("Profile,NP")
profile = GPath()
profile.moveto((0.0, 0.0))
profile.lineto((BOARD_W, 0.0))
profile.lineto((BOARD_W, BOARD_H))
profile.lineto((0.0, BOARD_H))
profile.lineto((0.0, 0.0))
edge_cuts.add_traces_path(profile, 0.1, "Profile")

with open(OUT / "board-Edge_Cuts.gbr", "w") as fh:
    edge_cuts.dump_gerber(fh)

# =============================================================================
# Excellon drill files -- HAND WRITTEN. gerber_writer has no Excellon support
# (verified: no excellon-related module/class in the installed package).
# The implementation child (019eb47ddebc) owns drill generation directly;
# this is a minimal, spec-plausible Excellon emitter for spike purposes only.
# =============================================================================


def write_excellon(path: Path, tools: dict, holes: list, comment: str):
    """tools: {tool_no: diameter_mm}; holes: [(tool_no, x_mm, y_mm), ...]"""
    lines = []
    lines.append("M48")
    lines.append(f";{comment}")
    lines.append(f";CREATED_BY=gerber-writer-spike/generate.py {datetime.date.today().isoformat()}")
    lines.append(";FORMAT={3:3/ absolute / metric / decimal}")
    lines.append("FMAT,2")
    lines.append("METRIC")
    for tool_no, dia in tools.items():
        lines.append(f"T{tool_no}C{dia:.3f}")
    lines.append("%")
    lines.append("G90")
    lines.append("G05")
    current_tool = None
    for tool_no, x, y in holes:
        if tool_no != current_tool:
            lines.append(f"T{tool_no}")
            current_tool = tool_no
        lines.append(f"X{x:.3f}Y{y:.3f}")
    lines.append("M30")
    path.write_text("\n".join(lines) + "\n")


# Plated: U1 TH pad drill + via drill
write_excellon(
    OUT / "board-PTH.drl",
    tools={1: TH_DRILL, 2: VIA_DRILL},
    holes=[(1, U1[0], U1[1]), (2, VIA[0], VIA[1])],
    comment="PLATED THROUGH HOLES",
)

# Non-plated: one mounting hole
write_excellon(
    OUT / "board-NPTH.drl",
    tools={1: MOUNT_HOLE_DIA},
    holes=[(1, MOUNTING_HOLE[0], MOUNTING_HOLE[1])],
    comment="NON-PLATED HOLES",
)

print(f"Wrote 6 gerber layers + 2 drill files to {OUT}")
