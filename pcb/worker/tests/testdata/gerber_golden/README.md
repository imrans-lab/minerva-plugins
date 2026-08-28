# Gerber / Excellon goldens (production path)

These files are the pinned output of `pcb_worker.gerber.build_gerbers` — the
exact code the `gerbers` worker method runs — for two hand-authored boards.
`tests/test_gerbers.py` byte-compares fresh output against them.

Regenerate (only for a deliberate output change, then re-diff by hand):

```
cd pcb/worker
python tests/testdata/gerber_golden/regenerate.py
```

## Boards

| Base name    | Source board                                  | Exercises                                         |
|--------------|-----------------------------------------------|---------------------------------------------------|
| `board`      | `../../../../spikes/gerber/board.yaml`         | SMD pads, one TH pad, via, 3 traces, 1 NPTH hole  |
| `drilltest`  | `../gerber_boards/drilltest.yaml`              | plated + non-plated TH pads, via, 2 NPTH mount holes |
| `coupon_jlc1`| `../coupon_jlc1.yaml`                          | the PROMOTED public fab coupon (epoch CPN1): interior cutout on Edge.Cuts, filled copper pour, roundrect/oval/circle SMD apertures, real silk (owl + stroke text + designators), **legend on BOTH sides since CP2 S9**, profile-pinned rules, mask/paste/drill split |

`coupon_jlc1` is the K18 golden — the one authored to certify what a
FABRICATED board needs rather than only its own contents. Its layers were
blessed one at a time against stated intent in epoch CPN1 station S8 (parsed
independently with gerbonara, measured in integer nanometres, rendered in
gerbv); the bless record is on docket `019fe2fb843b` and the board's feature
list is in `../coupon_jlc1.README.md`. Regenerating it means re-blessing it.

**Re-blessed once since, in epoch CP2 station S9** (docket `019fe4c18b8b`),
when REV1 put "REV A" on the back. Exactly ONE artifact moved —
`coupon_jlc1-B_SilkS.gbr`, additively, 61 insertions and no deletions — and
the other ten were byte-identical, which is the check that a silk-only,
pad-less, drill-less bottom-side fixture must pass. The orientation of the new
legend was blessed the same way the CPN1 layers were: parsed back with
gerbonara and compared against an independently-rendered upright reference,
NOT against our own emitter's self-report. That comparison is now a standing
test (`test_coupon_board.py::TestBackSilkReadsFromTheBack`) rather than a
one-off bless, because a legend rotated 180° is perfectly byte-stable and
would re-bless cleanly forever.

**Re-blessed again when the board went to ONE typeface.** Reference designators
used to be drawn from a separate 26-glyph table (a subset of KiCad's
GPL-2.0-or-later Newstroke, embedded in a proprietary repo); they now use the
same in-house `board_font.py` as board legend. EXACTLY five `*-F_SilkS.gbr`
artifacts moved anywhere in the repository — the four in THIS directory
(`board`, `drilltest`, `coupon_jlc1`, `quadlayer`), plus
`../../oracle/golden_emitter/board-F_SilkS.gbr`, which is a SECOND, separate
capture of the same `board` fixture (the emitter drift-pin snapshot) and
therefore always moves with this directory's `board-F_SilkS.gbr`. The full set
is enumerable with `git diff --stat <base>..HEAD -- '*.gbr'`. Within all five,
only `D01`/`D02` coordinate lines under the existing `%ADD10C,0.15*%`
aperture: no aperture was added, removed or resized, no copper/mask/paste/
drill/edge/gbrjob byte changed, and on `coupon_jlc1` the first 153 lines (the
owl, its baked "TEST COUPON" legend, the board text) are untouched — the whole
delta is one contiguous designator block. `coupon_jlc1-B_SilkS.gbr` did not
move: the coupon carries no bottom-side designator. The glyphs themselves are
what changed shape; the designator's cap height is still exactly 1.0 mm, and
its baseline now sits ON the anchor instead of 0.047619 mm below it (Newstroke
drew its baseline at a small negative local y; the 5x7 grid puts it at 0).

**Re-blessed once more when the coupon's own baked legend joined that
typeface** (bug `01a045e4da8e`). `LOGO_Owl_TestCoupon.kicad_mod` drew its
"TEST COUPON" legend as 96 `fp_line`s generated in 2026-08 from a Newstroke
subset, which made the footprint's `LicenseRef-TurnRock-Proprietary` lock entry
— and therefore `pcb/NOTICE.md` — say something untrue about shipped artwork.
The 96 segments were re-emitted from `board_font.render(..., h_align="center")`
at the parameters measured off the originals: cap height 1.000 mm, both lines
centred on the footprint's x=0, baselines at local y 1.652 ("TEST") and 3.052
("COUPON"), layer `F.SilkS`, stroke width 0.15 mm — so the legend keeps its
size, box and placement and the coupon layout does not move. 56 segments come
out instead of 96 (a 5x7 grid needs fewer than a Newstroke outline). The owl
(`fp_arc`, four `fp_circle`, `fp_poly`, five `fp_line`) and the courtyard are
byte-identical, and the footprint was re-blessed in
`pcb/library/footprints.lock.json` (`ea506c4a…` -> `2fe053e2…`).

EXACTLY ONE artifact moved: `coupon_jlc1-F_SilkS.gbr`, in ONE contiguous hunk
after line 34, 109 lines out and 69 in, every one of them a `D01`/`D02`
coordinate under the existing `%ADD10C,0.15*%` aperture — no aperture added,
removed or resized, no copper/mask/paste/drill/edge/gbrjob byte changed, and
the owl block ahead of the hunk untouched. The moved coordinates stay inside
the legend's own box (LOGO1 sits at 17.5, 14: y spans exactly -14.652 ..
-17.052 before and after, x narrows from 14.595 .. 20.357 to 15.083 .. 19.917
as the narrower glyphs predict). `coupon_jlc1-B_SilkS.gbr` did not move — the
back legend is `TXT_CouponRev`, not this footprint.

## Pinned versions (byte-stability holds ONLY at these)

| package       | version | role                                          |
|---------------|---------|-----------------------------------------------|
| gerber-writer | 0.4.3.3 | RS-274X/X2 layer writer (runtime dependency)   |
| pygerber      | 2.4.3   | independent round-trip parser (test dependency)|

Python 3.12. gerber-writer self-declares the coordinate format from each board's
extent (`%FSLAX36Y36*%` for boards under ~1000 mm), so goldens are NOT portable
across board sizes or a library upgrade — see `../../../docs/gerbers.md`.

The `TF.CreationDate` / Excellon `CREATED_BY` stamp is pinned to a fixed sentinel
(`1970-01-01T00:00:00`) by `build_gerbers` so output is byte-reproducible.
