# Fabrication Package Submission: Coupon-002 (jlc-coupon-1, rev A)

**Generated:** 2026-08-12
**Git base SHA:** f4e28c8198e64fb86a75d7d53b8fb439b54790a8
**Branch:** main
**Board source:** `pcb/worker/tests/testdata/coupon_jlc1.yaml` (board-source **v2**, sha256 `c158989309e609d88b3ef0f5ad9deea625a1b3749f3109a47fedc7627d9d5fb9`)
**Rule profile:** jlcpcb-2layer v1 (digest `3e1715e01ad60a243cd64a558d16cd98d4e6771aeb2eb5616364c43c0eae01fc`)
**Emitter:** `pcb_worker/gerber.py` v0.2.0 via `build_gerbers_ir()` (production IR-native path)
**Gerber library:** gerber-writer 0.4.3.3

## Reproduction Command

```bash
cd /home/imran/github/minerva-plugins/pcb/worker
.venv/bin/python -c "
from pathlib import Path
from pcb_worker.methods import handle_request
handle_request({'id':1,'method':'gerbers','params':{
    'yaml': Path('tests/testdata/coupon_jlc1.yaml').read_text(),
    'name': 'jlc-coupon-1',
    'out_dir': '/home/imran/github/minerva-plugins/pcb/fab/coupon-002'}})
"
```

This is the PRODUCT surface (the `gerbers` worker method behind
`minerva_pcb_gerbers`), not a test helper — an improvement over coupon-001's
`tests.gerber_fab` reproduction path.

## What this coupon evaluates

Fabrication-floor test vehicle for the jlcpcb-2layer profile: 0.10 mm minimum
trace ladder (NET_LAD1/NET_LAD2), near-floor annular ring (TP1, drill 0.6 /
annulus 0.96), mask dam at the sliver floor (DAM1), authored per-pad mask
margins (C1 roundrect + oval), fiducials with 2:1 mask windows, an interior
cutout, a bottom pour with keepout, and back-side legend (REV A, mirror-written).

## Verification chain (all at the SHA above)

- `promote_check` (K13 gate): **promotable: true** — connectivity clean,
  geometric DRC clean (0 findings) against jlcpcb-2layer, assembly pass.
- Geometric DRC advisories: 4, all `gc9_silk_width` on J1's vendored stock
  KiCad footprint (0.12 vs 0.15 floor) — accepted upstream artifact.
- Four-surface parity harness (ir/drc/kicad/gerber, incl. the solder-mask
  family): clean.
- Silk placement guards (`TestSilkStaysOnTheBoard`): 0 strokes off-board,
  0 in the cutout, designators only on J1 + DAM1 (fixture footprints author
  hidden references).
- All 10 GEOMETRY files are **byte-identical** to the blessed byte-goldens
  (`worker/tests/testdata/gerber_golden/coupon_jlc1-*`). The one exception is
  the `.gbrjob`, which embeds the output basename in its Name/GUID/Path fields
  (`jlc-coupon-1` here vs the goldens' `coupon_jlc1`) — a self-referential
  naming difference, zero geometry.
- Worker suite 2345 passed; CI green (3 platforms + hermetic fab gate +
  kicad-cli oracle) at this SHA.

## File Inventory

| Filename | Bytes | Function |
|----------|-------|----------|
| jlc-coupon-1-B_Cu.gbr | 1840 | Copper,L2,Bot,Signal |
| jlc-coupon-1-B_Mask.gbr | 712 | Soldermask,Bot |
| jlc-coupon-1-B_Paste.gbr | 269 | SolderPaste,Bot |
| jlc-coupon-1-B_SilkS.gbr | 969 | Legend,Bot |
| jlc-coupon-1-Edge_Cuts.gbr | 562 | Profile,NP |
| jlc-coupon-1-F_Cu.gbr | 3892 | Copper,L1,Top,Signal |
| jlc-coupon-1-F_Mask.gbr | 1759 | Soldermask,Top |
| jlc-coupon-1-F_Paste.gbr | 1152 | SolderPaste,Top |
| jlc-coupon-1-F_SilkS.gbr | 4897 | Legend,Top |
| jlc-coupon-1-job.gbrjob | 2670 |  |
| jlc-coupon-1-PTH.drl | 357 |  |

No NPTH drill file: the board has no unplated holes (known corpus gap
019fe59978, deliberate).

## Human review status

- [ ] Viewed in KiCad gerbview (owner) — REQUIRED before ordering
  (docs/gerbers.md: fab-correctness still needs a human viewer check).
