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
same in-house `board_font.py` as board legend. EXACTLY the four `*-F_SilkS.gbr`
files moved — `board`, `drilltest`, `coupon_jlc1`, `quadlayer` — and within
them only `D01`/`D02` coordinate lines under the existing `%ADD10C,0.15*%`
aperture: no aperture was added, removed or resized, no copper/mask/paste/
drill/edge/gbrjob byte changed, and on `coupon_jlc1` the first 153 lines (the
owl, its baked "TEST COUPON" legend, the board text) are untouched — the whole
delta is one contiguous designator block. `coupon_jlc1-B_SilkS.gbr` did not
move: the coupon carries no bottom-side designator. The glyphs themselves are
what changed shape; the designator's cap height is still exactly 1.0 mm, and
its baseline now sits ON the anchor instead of 0.047619 mm below it (Newstroke
drew its baseline at a small negative local y; the 5x7 grid puts it at 0).

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
