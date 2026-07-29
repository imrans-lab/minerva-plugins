#!/usr/bin/env python
"""Gerber-writer validation spike: generate a tiny 2-layer test board.

Board geometry mirrors board.yaml (canonical board-source contract terms).
Emits RS-274X/X2 layers via the `gerber_writer` library (F.Cu, B.Cu, F.Paste,
B.Paste, F.SilkS, B.SilkS, F.Mask, B.Mask, Edge.Cuts) plus hand-written Excellon
drill files (PTH and NPTH) since gerber_writer has no Excellon support at all
(confirmed by reading its source: no `excellon` module, no drill-related class).

ANTI-CIRCULARITY IS THE WHOLE POINT OF THIS FILE. It builds the golden directly
against the gerber_writer API and must NEVER import pcb_worker. Every constant
below is restated here on purpose: if this file read the emitter's numbers, the
correctness oracle would be comparing the emitter against itself. Where a value
matches production (mask clearance, edge stroke) the comment says WHERE the
production number comes from — it does not import it.

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
# compile->IR fab path pins solder_mask_clearance_mm to 0.05mm from compile_board's
# v1 manufacturing floor (compile_board._V1_MANUFACTURING_FLOOR) and ignores any
# authored value, so this INDEPENDENT golden must be cut at the same clearance for
# the correctness oracle to certify user-facing CAM. Was 0.1mm
# (legacy DEFAULT_MASK_CLEARANCE_MM in gerber.py, which now only applies to the raw
# test path). The NPTH mount mask below is a drill-size opening and is unaffected.
MOUNT_HOLE_DIA = 3.2
# Board-outline stroke. RATIFIED to match production, which single-sources it as
# fab_capability.EDGE_CUTS_WIDTH_MM — itself KiCad's own default, measured off
# BOARD_DESIGN_SETTINGS.GetLineThickness(Edge_Cuts) in 10.0.5. Was 0.1 here.
# Restated as a literal, NOT imported: this generator must stay independent of
# the emitter it is used to check. Fabrication-immaterial either way (board
# houses route the outline centreline), so this is a bookkeeping alignment, not
# a defect fix.
EDGE_STROKE = 0.05

r1_pin1 = (R1[0] - 0.95, R1[1])
r1_pin2 = (R1[0] + 0.95, R1[1])
c1_pin1 = (C1[0] - 0.95, C1[1])
c1_pin2 = (C1[0] + 0.95, C1[1])


# --- BOARD frame -> GERBER frame ---------------------------------------------
# Every constant above is in the BOARD frame (KiCad's file frame, Y-DOWN, the
# frame board.yaml is authored in). RS-274X and Excellon are Y-UP. G() is the
# frame boundary: negate Y, per vertex, at each write-site. Applied per vertex
# rather than by pre-negating the constants so every emitted path keeps its
# original start corner and winding and is the exact MIRROR of what this
# generator always drew.
def G(pt):
    """BOARD frame (Y-down) -> GERBER frame (Y-up)."""
    return (pt[0], -pt[1])

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
f_cu.add_pad(smd_pad, G(r1_pin1))
f_cu.add_pad(smd_pad, G(r1_pin2))
f_cu.add_pad(smd_pad, G(c1_pin1))
f_cu.add_pad(smd_pad, G(c1_pin2))
f_cu.add_pad(th_pad_cu, G(U1))          # TH pad has copper on every copper layer
f_cu.add_pad(via_pad_cu, G(VIA))
# VCC: R1.2 -> via
f_cu.add_trace_line(G(r1_pin2), G(VIA), TRACE_W, "Conductor")
# GND: R1.1 -> C1.1
f_cu.add_trace_line(G(r1_pin1), G(c1_pin1), TRACE_W, "Conductor")

with open(OUT / "board-F_Cu.gbr", "w") as fh:
    f_cu.dump_gerber(fh)

# =============================================================================
# B.Cu
# =============================================================================
b_cu = DataLayer("Copper,L2,Bot,Signal", negative=False)
b_cu.add_pad(th_pad_cu, G(U1))
b_cu.add_pad(via_pad_cu, G(VIA))
# VCC: via -> U1 TH pad, single trace on B.Cu
b_cu.add_trace_line(G(VIA), G(U1), TRACE_W, "Conductor")

with open(OUT / "board-B_Cu.gbr", "w") as fh:
    b_cu.dump_gerber(fh)

# =============================================================================
# F.Mask (openings; vias left tented -> not present in mask layer)
# =============================================================================
f_mask = DataLayer("Soldermask,Top", negative=False)
f_mask.add_pad(smd_mask_pad, G(r1_pin1))
f_mask.add_pad(smd_mask_pad, G(r1_pin2))
f_mask.add_pad(smd_mask_pad, G(c1_pin1))
f_mask.add_pad(smd_mask_pad, G(c1_pin2))
f_mask.add_pad(th_mask_pad, G(U1))
f_mask.add_pad(mount_mask_pad, G(MOUNTING_HOLE))   # NPTH: drill-size opening

with open(OUT / "board-F_Mask.gbr", "w") as fh:
    f_mask.dump_gerber(fh)

# =============================================================================
# B.Mask (U1's TH pad copper + the NPTH mounting-hole drill-size opening)
# =============================================================================
b_mask = DataLayer("Soldermask,Bot", negative=False)
b_mask.add_pad(th_mask_pad, G(U1))
b_mask.add_pad(mount_mask_pad, G(MOUNTING_HOLE))   # NPTH: drill-size opening

with open(OUT / "board-B_Mask.gbr", "w") as fh:
    b_mask.dump_gerber(fh)

# =============================================================================
# F.Paste / B.Paste -- solder-paste stencil apertures
#
# THE MEASURED RULE (KiCad 10.0.5's own Gerber export, F.Paste aperture vs the
# F.Cu aperture for the same pad): with NO authored solder_paste_margin, the
# stencil opening is the SAME SIZE as the copper land. Not inset. So the four
# 0805 lands get four 1.0 x 1.45 apertures, identical to their copper.
#
# The aperture FUNCTION differs from copper: copper carries "SMDPad,CuDef", a
# stencil aperture carries none (the X2 file attribute SolderPaste,Top on the
# LAYER says what it is), exactly as the mask masters above do.
#
# U1's through-hole pad gets NO paste: KiCad's shipped TH footprints declare
# "*.Cu" "*.Mask" and nothing else, so no paste layer participation exists to
# emit. The via likewise gets none -- measured, a via's annulus appears on both
# copper layers and on neither paste layer.
#
# B.Paste is written and EMPTY: this board has no bottom-side SMD. KiCad emits
# an empty B_Paste for such a board too, and a fab package with a silently
# ABSENT layer is worse than one with an empty layer.
# =============================================================================
smd_paste_pad = Rectangle(SMD_PAD_X, SMD_PAD_Y, "")

f_paste = DataLayer("SolderPaste,Top", negative=False)
f_paste.add_pad(smd_paste_pad, G(r1_pin1))
f_paste.add_pad(smd_paste_pad, G(r1_pin2))
f_paste.add_pad(smd_paste_pad, G(c1_pin1))
f_paste.add_pad(smd_paste_pad, G(c1_pin2))

with open(OUT / "board-F_Paste.gbr", "w") as fh:
    f_paste.dump_gerber(fh)

b_paste = DataLayer("SolderPaste,Bot", negative=False)

with open(OUT / "board-B_Paste.gbr", "w") as fh:
    b_paste.dump_gerber(fh)

# =============================================================================
# F.SilkS -- component courtyard outlines + a pin-1 tick for U1
# =============================================================================
f_silks = DataLayer("Legend,Top", negative=False)


def _courtyard(center, half_w, half_h):
    p = GPath()
    cx, cy = center
    p.moveto(G((cx - half_w, cy - half_h)))
    p.lineto(G((cx + half_w, cy - half_h)))
    p.lineto(G((cx + half_w, cy + half_h)))
    p.lineto(G((cx - half_w, cy + half_h)))
    p.lineto(G((cx - half_w, cy - half_h)))
    return p


f_silks.add_traces_path(_courtyard(R1, 1.6, 1.0), 0.15, "")
f_silks.add_traces_path(_courtyard(C1, 1.6, 1.0), 0.15, "")
# Pin-1 tick mark near U1 (short line offset from the pad, not overlapping copper)
tick = GPath()
tick.moveto(G((U1[0] - TH_ANNULUS / 2 - 0.6, U1[1])))
tick.lineto(G((U1[0] - TH_ANNULUS / 2 - 0.2, U1[1])))
f_silks.add_traces_path(tick, 0.15, "")

with open(OUT / "board-F_SilkS.gbr", "w") as fh:
    f_silks.dump_gerber(fh)

# =============================================================================
# B.SilkS -- written, EMPTY. This board has no bottom-side component, so there
# is no back legend to draw. Present for fab-package completeness, exactly as
# KiCad emits an empty board-B_Silkscreen.gbo in the same situation.
# =============================================================================
b_silks = DataLayer("Legend,Bot", negative=False)

with open(OUT / "board-B_SilkS.gbr", "w") as fh:
    b_silks.dump_gerber(fh)

# =============================================================================
# Edge.Cuts -- board outline rectangle, 0,0 -> 40,30
# =============================================================================
edge_cuts = DataLayer("Profile,NP")
profile = GPath()
profile.moveto(G((0.0, 0.0)))
profile.lineto(G((BOARD_W, 0.0)))
profile.lineto(G((BOARD_W, BOARD_H)))
profile.lineto(G((0.0, BOARD_H)))
profile.lineto(G((0.0, 0.0)))
edge_cuts.add_traces_path(profile, EDGE_STROKE, "Profile")

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
        gx, gy = G((x, y))
        lines.append(f"X{gx:.3f}Y{gy:.3f}")
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

print(f"Wrote 9 gerber layers + 2 drill files to {OUT}")
