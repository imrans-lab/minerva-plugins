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

## Captured through the production (IR) path

Since K4 phase 1 this snapshot is captured through the production fab path,
exactly as `methods._gerbers` runs it: COMPILE (strict) → `ir_to_board_dict` →
`build_gerbers(placed=True)` (via `tests/gerber_fab.build_fab`). The raw board
cannot be captured directly: its SMD pins carry no inline geometry, so the
emitter fails closed rather than writing a placeholder land. The SMD copper pads
here are the REAL `1.0 x 1.45 mm` 0805 lands resolved from the seed library. NB
the solder-mask openings now carry the compiler's resolved `0.05 mm` per-side
clearance (`R,1.1X1.55` / `C,1.7`) rather than the `0.1 mm` default the legacy
`resolve_board_best_effort` path used — the corrected bytes this drift pin now
tracks. F.SilkS still differs from the correctness reference (`spike-gerber-v1`):
the emitter draws courtyards procedurally; silk is excluded from the correctness
oracle (Option A).

Note: `pcb/scripts/capture_emitter_golden.py` (out of the K4 phase-1 fence) still
captures via the legacy `resolve_board_best_effort` path; this snapshot was
regenerated to the IR path by hand. That script must be migrated to `build_fab`
in the phase that deletes `build_gerbers(placed=False)`.

## Regenerating (intentional emitter changes only)

```
python pcb/scripts/capture_emitter_golden.py
```

Then re-run `pcb/worker/.venv/bin/python -m pytest tests/ -q` and review the diff.
