# Fabrication Package Submission: Coupon-001

**Generated:** 2026-07-29  
**Git base SHA:** 5de84453d3ddb480219d6a10e2d9404e22b9ff37  
**Branch:** main

## Reproduction Command

```bash
cd /home/imran/github/minerva-plugins/pcb/worker
.venv/bin/python -c "
from tests.gerber_fab import build_fab
build_fab(
    '/home/imran/github/minerva-plugins/pcb/spikes/gerber/board.yaml',
    'board',
    out_dir='/home/imran/github/minerva-plugins/pcb/fab/coupon-001'
)
"
```

Use `.venv/bin/python`, not a bare `python3`. On this machine the two happen to resolve to the
same interpreter (3.12.4) and the same `gerber-writer` (0.4.3.3), so the package is unaffected —
but that is a coincidence of this box, not a guarantee, and pinning the interpreter is what makes
the command reproducible elsewhere.

Note the import path: `tests.gerber_fab`. This is a TEST helper, not a product command. See
"Emitter Artifact Notes" below.

**Emitter:** `pcb_worker/gerber.py` v0.2.0 via `build_gerbers_ir()` (production IR-native path)  
**Board source:** `pcb/spikes/gerber/board.yaml` (canonical board model)  
**Gerber library:** gerber-writer 0.4.3.3

---

## File Inventory

| Filename | Size (bytes) | Layer | Purpose |
|----------|-------------|-------|---------|
| board-F_Cu.gbr | 920 | Copper,L1,Top | Front copper layer |
| board-B_Cu.gbr | 642 | Copper,L2,Bot | Back copper layer |
| board-F_Mask.gbr | 603 | SolderMask,Top | Front solder mask openings |
| board-B_Mask.gbr | 445 | SolderMask,Bot | Back solder mask openings |
| board-F_Paste.gbr | 434 | SolderPaste,Top | Front solder paste stencil |
| board-B_Paste.gbr | 269 | SolderPaste,Bot | Back solder paste stencil (empty) |
| board-F_SilkS.gbr | 2020 | Legend,Top | Front silk screen (component outlines + pin-1 marker) |
| board-B_SilkS.gbr | 264 | Legend,Bot | Back silk screen (empty) |
| board-Edge_Cuts.gbr | 445 | Profile | Board outline / routing path |
| board-PTH.drl | 206 | Plated Drill | Plated through-hole drills (2 holes) |
| board-NPTH.drl | 172 | Non-Plated Drill | Non-plated holes (1 mounting hole) |
| board-job.gbrjob | 2602 | Job File | Fabrication job metadata (RS-274D/X2) |

**Total:** 12 files, 9,022 bytes (`ls -l | awk` sum; an earlier draft said 8,672,
which was wrong by 350 — the individual sizes were all correct)

**Two placeholders in `board-job.gbrjob` a house may read literally:**
`"Finish": "None"` and `"Revision": "rev?"`. Surface finish is listed as
"to be specified" in the table below, but the manifest asserts *None* — override
it explicitly on the order form, or a house could take it at face value.

---

## Measured Board Parameters

### Dimensions
- **Width:** 40.0 mm  
- **Height:** 30.0 mm  
- **Measurement source:** `board-Edge_Cuts.gbr` coordinates. The outline traces
  `X0Y0 → X40000000Y0 → X40000000Y-30000000 → X0Y-30000000`. In `%FSLAX36Y36*%`
  (3.6) format one unit is 10⁻⁶ mm, so 40000000 = 40.0 mm — NOT microns, and note
  Y runs 0 → **−**30000000, consistent with the Y negation described under Drill
  File Notes.
- **Outline stroke vs. quoted size:** `board-job.gbrjob` declares
  `"Size": {"X": 40.05, "Y": 30.05}` — the outline bounding box INCLUDING the
  0.05 mm Edge.Cuts stroke. The finished board is 40.0 × 30.0 mm because houses
  route the outline centreline. Both numbers are correct; they measure different
  things.

### Copper & Layer Stack
- **Layer count:** 2 (top + bottom copper)  
- **Copper thickness:** 0.035 mm per layer (from job file, standard 1 oz weight assumption)  
- **Dielectric (FR4 core):** 1.51 mm  
- **Total finished thickness (default):** 1.6 mm  
- **Measurement source:** board-job.gbrjob MaterialStackup

### Mask & Paste
- **Solder mask clearance:** 0.05 mm per side  
  - Measurement: SMD pad copper 1.0×1.45 mm → mask opening 1.1×1.55 mm (delta 0.05 mm each side)  
  - Source: board-F_Mask.gbr apertures  
- **Paste aperture:** Equals copper land size (no inset margin)  
  - F_Paste SMD pads: 1.0×1.45 mm (matches copper)  
  - Source: board-F_Paste.gbr apertures
- **Through-hole paste:** None (no *.Paste declaration on TH pads per KiCad footprint design)

### Traces & Routing
- **Trace width (minimum actual):** 0.25 mm  
  - Measurement: F_Cu aperture %ADD13C,0.25*% (conductor width)  
  - Source: board-F_Cu.gbr
- **Trace-to-trace spacing (minimum actual):** Not measurable as critical dimension  
  - Reason: Traces on this board do not run parallel; VCC and GND traces separate immediately after component pads  
  - However, design-rule minimum clearance is 0.2 mm (from job file DesignRules)  
  - Source: board-job.gbrjob MinLineWidth 0.127 mm, PadToPad/PadToTrack/TrackToTrack clearance 0.2 mm

### Drills
- **Via drill (plated):** 0.4 mm  
  - Count: 1 (at X20.0 Y10.0 mm)  
  - Via annulus (pad): 0.8 mm diameter  
  - Measurement source: board-PTH.drl tool T1C0.400
- **Through-hole pad drill (plated):** 0.8 mm  
  - Count: 1 (at X30.0 Y15.0 mm, U1 test point)  
  - TH annulus (pad): 1.6 mm diameter  
  - Measurement source: board-PTH.drl tool T2C0.800
- **Mounting hole (non-plated):** 3.2 mm  
  - Count: 1 (at X5.0 Y5.0 mm)  
  - No mask opening growth (drill-size opening, per KiCad np_thru_hole convention)  
  - Measurement source: board-NPTH.drl tool T1C3.200
- **Smallest drill on board:** 0.4 mm (via)

---

## Design Parameters Summary

These are the values the owner must communicate to the fabrication house at order time:

| Parameter | Value | Source |
|-----------|-------|--------|
| **Board Dimensions** | 40.0 × 30.0 mm | Measured |
| **Finished Thickness** | 1.6 mm (default FR4) | **To be specified** |
| **Copper Weight** | 1 oz (0.035 mm/side, default) | **To be specified** |
| **Surface Finish** | (HASL/ENIG/OSP/etc.) | **To be specified** |
| **Solder Mask Color** | (Green/Red/Blue/Black/etc.) | **To be specified** |
| **Silk Screen Color** | (White/Black/Yellow) | **To be specified** |
| **Layer Count** | 2 (2 copper + 7 non-copper) | Measured |
| **Min Trace Width** | 0.25 mm | Measured (actual) |
| **Min Clearance** | 0.2 mm | From design rules |
| **Min Solder Mask Clearance** | 0.05 mm/side | Measured |
| **Smallest Drill** | 0.4 mm (via) | Measured |

---

## WHAT TO RECORD AT INTAKE

When submitting this package to a board house, **capture and record the following from their DFM check report:**

1. **Every DFM warning** reported by the house (even if they say "auto-repair applied"):
   - Design rule violations  
   - Trace width issues  
   - Clearance violations  
   - Drill size warnings  
   - Layer stackup confirmations  
   - Mask/paste alignment issues  

2. **Every automatic repair** the house reports making:
   - Trace width corrections  
   - Via/drill diameter adjustments  
   - Mask opening resizing  
   - Layer merging or splitting  
   - Pad aperture corrections  

3. **Any file read errors or warnings:**
   - Files the house could not parse  
   - Coordinate format issues  
   - Missing or unrecognized layers  
   - Attribute parsing failures  

4. **Stackup confirmation:**
   - Verify the house has accepted 2-layer FR4 with 0.035 mm copper per side  
   - Confirm dielectric thickness (1.51 mm core + 2×0.01 mm mask + 2×0.035 mm copper ≈ 1.6 mm finished)  
   - Note any thickness tolerance they impose  

**Use:** This feedback becomes the input to the **manufacturer profile** (a separate deferred item per the project record). The profile will document what this house auto-repaired, what it rejected, and how subsequent boards for this house should be pre-adjusted to avoid repeated corrections.

---

## KNOWN GAPS IN THIS PACKAGE

**This bare-board fabrication package is INCOMPLETE for assembly.** The house can manufacture this as a **bare PCB only** — no components can be soldered by them without these missing artifacts:

1. **No Assembly Drawing (Fab Drawing / Notes)**
   - No coordinate system, origin, or reference marks defined  
   - No layer stackup diagram  
   - No notes on testing, depanelization, or handling requirements  

2. **No Centroid File (CPL) & No Bill of Materials (BOM)**
   - No component placement list for pick-and-place automation  
   - No BOM with part numbers, quantities, values, or sourcing  
   - **Result:** The house cannot auto-populate this board; manual assembly only  

3. **No Drill Map or Legend**
   - No visual diagram showing hole functions (via, test point, mounting, etc.)  
   - No annotation of which drill tool corresponds to which hole type  

4. **No IPC Netlist (IPC-356 test points)**
   - No electrical continuity test instructions  
   - Bare board electrical testing is undefined  

**Bottom line:** This package produces a **bare PCB** that can be hand-assembled. For **full turnkey fabrication + pick-and-place assembly**, the following must be added:
   - Assembly drawing with coordinates and BOM cross-reference  
   - Centroid file (X, Y, rotation for each component)  
   - Complete BOM with part numbers and sourcing  
   - IPC-356 netlist for electrical test (if required)  

---

## Gerber Validation

- **Polarity — THIS PACKAGE CONTAINS A KNOWN DEFECT. READ BEFORE ORDERING.**
  Every file, mask included, uses `%LPD*%` in its body, which is correct and
  matches KiCad. But the two mask artifacts disagree about the FILE-level
  polarity attribute: `board-F_Mask.gbr` / `board-B_Mask.gbr` declare
  `TF.FilePolarity,Positive`, while `board-job.gbrjob` declares
  `"FilePolarity": "Negative"` for those same files.
  **Measured 2026-07-29 against KiCad 10.0.5** (`kicad-cli pcb export gerbers`
  on the independent `pic_programmer` demo board): KiCad emits
  `%TF.FilePolarity,Negative*%` together with `%LPD*%`. Those are different
  things — FilePolarity says the features represent mask OPENINGS; `%LPD` is the
  plot polarity of the draws. Corroborated by a KiCad 7.0.6 export.
  **Verdict: the job file is right, the `.gbr` attribute is wrong.** A house whose
  intake trusts the file attribute over the manifest would invert the mask —
  solder mask over every pad, bare laminate elsewhere. Tracked as docket
  019fb0c348f2; the fix is two lines but moves the blessed golden, so it is an
  owner call and is NOT in this package.
- **Coordinate format:** self-declared `%FSLAX36Y36*%` — **3 integer digits and 6
  decimal digits** (Gerber "3.6"), absolute, leading zeros omitted, unit mm.
  ("36-bit signed" in an earlier draft was wrong; bit width is not a Gerber
  concept.)
- **X2 attributes:** Backward-compatible comment form (G04 #@! TF.../TA.../TD.*) — fully RS-274X legal  
- **Aperture list:** Each layer declares only apertures it uses (no junk); apertures match feature geometry  
- **No arcs in this board:** All paths are linear (G01) — no G02/G03 arc instructions  
- **Bottom-side mirror applied:** Via and TH pad appear on both F.Cu and B.Cu; traces on B.Cu are routed from via downward

---

## Drill File Notes (Excellon)

- **Format:** FMAT,2 (metric, absolute, 3:3 decimal)  
- **PTH file:** 2 plated holes (via 0.4 mm + TH pad 0.8 mm)  
- **NPTH file:** 1 non-plated hole (3.2 mm mounting)  
- **Coordinate frame:** Y-negated relative to board frame (Gerber convention, Y-UP)  
- **No slot definitions:** The Excellon files contain only round holes; no routed slots  

---

## Emitter Artifact Notes

- **Determinism:** Creation date pinned to 1970-01-01T00:00:00 (for byte-reproducible golden comparison)
- **What these bytes match, stated precisely, because an earlier draft of this
  document got it wrong in the flattering direction.** All 12 files are
  byte-identical to `pcb/worker/tests/testdata/gerber_golden/`. That set is
  regenerated by `regenerate.py` calling `build_fab` → `build_gerbers_ir` — the
  same function that produced this package. **So that comparison is the emitter
  against itself, and proves only determinism, not correctness.** It is
  registered in `PROVENANCE.json` as `emitter-snapshot-v1` with
  `blessed: false` and the standing note "Inherently circular".
- **What they do NOT match:** the actually-blessed `spike-gerber-v1` golden,
  which lives at `pcb/spikes/gerber/golden` (a different path). Ignoring
  timestamps and generation-software lines, 5 of the 11 shared files differ:
  `F_Cu` (1 line), `F_Mask` (3), `B_Mask` (2), `F_Paste` (1), `F_SilkS` (89),
  `PTH.drl` (4). The differences are cosmetic or ordering — X2 `TAShape` `0` vs
  `0.0`, Excellon tool renumbering, and the known-excluded procedural silk —
  except one aperture float-noise case (see Known Divergences).
- **So what IS the independent evidence?** The owner's 2026-07-29 GerbView
  overlay of the *spike golden* against KiCad 10.0.5's own export. That is
  genuine and independent, but it covers the spike golden's bytes, which are not
  exactly these bytes, and a geometry overlay cannot see file-level attributes at
  all. `board-job.gbrjob` is in **no** blessed set — `pcb/spikes/gerber/golden`
  contains zero `.gbrjob` — which is exactly where the polarity defect below was
  hiding.
- **Oracle status:** the golden is a REGRESSION pin, not an independent oracle.
  Acceptance check K16 was re-censused from PASSING to FAILING on this point
  (docket 019fa92895d9).
- **Generated by:** the production emitter `pcb_worker/gerber.py
  build_gerbers_ir()`, reached here through the test helper
  `pcb/worker/tests/gerber_fab.py::build_fab`. An earlier draft claimed no
  product-surface fab command exists; **that was wrong.** `minerva_pcb_gerbers`
  is a shipped MCP tool (`manifest.json:500`, `methods.py:2024` → `_gerbers`,
  routed via `dispatcher.py`) that accepts `out_dir` and writes these files to
  disk through the same `_compile_or_fail` prologue. It would produce this
  package. Only the narrow claim was true: `build_fab` itself has no callers
  outside `worker/tests/`. Future coupons should use the shipped tool rather than
  a test helper.
- **Reproducibility caveat:** the working tree was DIRTY when these bytes were
  produced — `pcb/worker/pcb_worker/{fab_capability,footprints}.py` and
  `pcb/internal/board/**` were all modified relative to the SHA in the header.
  The Python changes are refusal-only and the Go changes are schema-only, and the
  output was re-verified byte-identical after both, so the bytes are unaffected.
  But a header that names a SHA should say the tree was not at it.

## Known Divergences

- **`%ADD11C,1.7000000000000002*%` in `board-F_Mask.gbr`.** The blessed spike
  golden has `%ADD11C,1.7*%`. This is float noise from `1.6 + 2 × 0.05`,
  physically identical to within 2 × 10⁻¹⁶ mm and legal Gerber, but it is the one
  non-cosmetic divergence from the blessed bytes, and some older CAM importers
  dislike long mantissas in an aperture definition. Aperture dimensions should be
  quantized before emission. Harmless for this order; noted so a house query
  about it is not a surprise.
- **X2 attribute asymmetry:** `F_Mask` apertures carry `TAShape` but no
  `TA.AperFunction` and no `TD*` closers, unlike `F_Cu`. Legal, but inconsistent.

