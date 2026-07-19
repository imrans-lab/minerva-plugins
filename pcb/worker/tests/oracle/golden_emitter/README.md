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

## Captured through the production (resolved) path

Since Stage 2 step 4a-ii (bug 019f7736b236) this snapshot is captured through the
production fab path: `resolve.resolve_board_best_effort(board.yaml)` then
`build_gerbers` — the same best-effort resolve `methods._gerbers` now runs by
default. The raw board can no longer be captured directly: its SMD pins carry no
inline geometry, so the emitter fails closed rather than writing a placeholder
land. The SMD copper pads here are therefore the REAL `1.0 x 1.45 mm` 0805 lands
resolved from the seed library, matching the (re-blessed) correctness reference
`spike-gerber-v1` on the fabrication-critical layers (F.SilkS still differs — the
emitter draws courtyards procedurally; silk is excluded from the correctness
oracle, Option A).

## Regenerating (intentional emitter changes only)

```
python pcb/scripts/capture_emitter_golden.py
```

Then re-run `pcb/worker/.venv/bin/python -m pytest tests/ -q` and review the diff.
