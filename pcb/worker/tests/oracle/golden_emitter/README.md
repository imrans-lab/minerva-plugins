# Emitter drift-pin snapshot (`emitter-snapshot-v1`)

**DRIFT-PIN ONLY — NOT A CORRECTNESS ORACLE.**

These files are a frozen capture of what `pcb_worker.gerber.build_gerbers`
emits *today* for `pcb/spikes/gerber/board.yaml` (`name="board"`). They exist so
that a future, unintended change to the emitter produces a **non-empty geometry
delta** in `tests/oracle/test_geometry_diff.py::test_regression_drift_pin`.

## Why this is not a correctness oracle

The snapshot is captured *from the emitter under test*, so pinning it "green"
only proves the emitter still agrees with its past self — it cannot prove the
past self was correct (that is the exact circularity SB.2 guards against). Its
provenance entry (`emitter-snapshot-v1` in
`../../../../spikes/gerber/golden/PROVENANCE.json`) is therefore **`blessed:
false` permanently, by design**, and `provenance.correctness_oracle_status`
refuses to hand it out as a correctness oracle.

The independent **correctness reference** is the hand-built,
structurally-validated golden at `pcb/spikes/gerber/golden/`
(`spike-gerber-v1`), whose external bless is deferred to a human — see
`../../../../spikes/gerber/golden/HOW_TO_BLESS.md`.

## Known divergence from the correctness reference

The current emitter output captured here **differs** from `spike-gerber-v1`:
SMD copper pads are the placeholder `1.0 x 0.6 mm` default (the spike golden
uses real `1.2 x 1.3 mm` 0805 pads), with the matching mask and F.SilkS
differences. That is a genuine finding — `board.yaml` pins carry no pad
geometry, so `build_gerbers` falls back to `DEFAULT_SMD_PAD_*`. See the SB.2
report.

## Regenerating (intentional emitter changes only)

```
python pcb/scripts/capture_emitter_golden.py
```

Then re-run `pcb/worker/.venv/bin/python -m pytest tests/ -q` and review the diff.
