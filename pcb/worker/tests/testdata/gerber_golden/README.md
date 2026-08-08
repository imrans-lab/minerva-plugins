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
| `coupon_jlc1`| `../coupon_jlc1.yaml`                          | the PROMOTED public fab coupon (epoch CPN1): interior cutout on Edge.Cuts, filled copper pour, roundrect/oval/circle SMD apertures, real silk (owl + stroke text + designators), profile-pinned rules, mask/paste/drill split |

`coupon_jlc1` is the K18 golden — the one authored to certify what a
FABRICATED board needs rather than only its own contents. Its layers were
blessed one at a time against stated intent in epoch CPN1 station S8 (parsed
independently with gerbonara, measured in integer nanometres, rendered in
gerbv); the bless record is on docket `019fe2fb843b` and the board's feature
list is in `../coupon_jlc1.README.md`. Regenerating it means re-blessing it.

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
